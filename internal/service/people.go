package service

import (
	"context"
	"time"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/store"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type People struct {
	pb.UnimplementedPeopleServiceServer
	Store *store.Store
}

func personToPB(p store.Person) *pb.Person {
	return &pb.Person{Id: p.ID, Name: p.Name, Fields: p.Fields,
		CreateTime: timestamppb.New(p.Created), UpdateTime: timestamppb.New(p.Updated)}
}

func (s *People) UpsertPerson(ctx context.Context, req *pb.UpsertPersonRequest) (*pb.Person, error) {
	u, err := uid(ctx)
	if err != nil {
		return nil, err
	}
	p, err := s.Store.UpsertPerson(ctx, u, req.GetName(), req.GetFields(), req.GetNewName(), time.Now())
	if err != nil {
		return nil, toStatus(err)
	}
	return personToPB(p), nil
}

func (s *People) GetPerson(ctx context.Context, req *pb.GetPersonRequest) (*pb.Person, error) {
	u, err := uid(ctx)
	if err != nil {
		return nil, err
	}
	p, err := s.Store.GetPerson(ctx, u, req.GetId(), req.GetName())
	if err != nil {
		return nil, toStatus(err)
	}
	return personToPB(p), nil
}

func (s *People) ListPeople(ctx context.Context, req *pb.ListPeopleRequest) (*pb.ListPeopleResponse, error) {
	u, err := uid(ctx)
	if err != nil {
		return nil, err
	}
	ps, err := s.Store.ListPeople(ctx, u, req.GetQuery(), int(req.GetPageSize()))
	if err != nil {
		return nil, toStatus(err)
	}
	out := &pb.ListPeopleResponse{}
	for _, p := range ps {
		out.People = append(out.People, personToPB(p))
	}
	return out, nil
}

func (s *People) DeletePerson(ctx context.Context, req *pb.DeletePersonRequest) (*emptypb.Empty, error) {
	u, err := uid(ctx)
	if err != nil {
		return nil, err
	}
	if err := s.Store.DeletePerson(ctx, u, req.GetId(), req.GetName()); err != nil {
		return nil, toStatus(err)
	}
	return &emptypb.Empty{}, nil
}
